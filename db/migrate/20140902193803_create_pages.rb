class CreatePages < ActiveRecord::Migration
  def up
    create_table :pages do |t|
      t.string :title
      t.text :content
      t.integer :category
      t.string :etag
      t.timestamps
    end
  end

  def down
    drop_table :pages
  end
end
